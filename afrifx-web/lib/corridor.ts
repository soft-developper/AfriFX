// Multi-corridor routing for Phase 2
// All local→local swaps route through USDC as the middle leg.
// Arc settles each leg independently in <1s.

import { SPREAD_BPS } from './contracts'
import type { Currency, SwapQuote, CorridorQuote } from '@/types'

export const LOCAL_CURRENCIES: Currency[] = [
  'NGN', 'GHS', 'KES', 'ZAR', 'EGP',
  'UGX', 'TZS', 'RWF', 'XOF', 'XAF', 'ZMW', 'ETB', 'MZN',
]

export const CURRENCY_LABELS: Record<Currency, string> = {
  NGN:  'Nigerian Naira',
  GHS:  'Ghanaian Cedi',
  KES:  'Kenyan Shilling',
  ZAR:  'South African Rand',
  EGP:  'Egyptian Pound',
  UGX:  'Ugandan Shilling',
  TZS:  'Tanzanian Shilling',
  RWF:  'Rwandan Franc',
  XOF:  'West African CFA Franc',
  XAF:  'Central African CFA Franc',
  ZMW:  'Zambian Kwacha',
  ETB:  'Ethiopian Birr',
  MZN:  'Mozambican Metical',
  USDC: 'USD Coin',
  EURC: 'Euro Coin',
}

export const CURRENCY_FLAG: Record<Currency, string> = {
  NGN:  '🇳🇬',
  GHS:  '🇬🇭',
  KES:  '🇰🇪',
  ZAR:  '🇿🇦',
  EGP:  '🇪🇬',
  UGX:  '🇺🇬',
  TZS:  '🇹🇿',
  RWF:  '🇷🇼',
  XOF:  '🌍',
  XAF:  '🌍',
  ZMW:  '🇿🇲',
  ETB:  '🇪🇹',
  MZN:  '🇲🇿',
  USDC: '💵',
  EURC: '🇪🇺',
}

// Every local currency swaps to every other local currency (all route through
// USDC), so corridors are DERIVED from LOCAL_CURRENCIES rather than hardcoded.
// Adding a currency above automatically enables all of its corridors, with no
// long pair list to maintain by hand.
export const CORRIDORS: [Currency, Currency][] = LOCAL_CURRENCIES.flatMap(
  (from, i) => LOCAL_CURRENCIES.slice(i + 1).map(to => [from, to] as [Currency, Currency])
)

export function isCorridorSupported(from: Currency, to: Currency): boolean {
  return CORRIDORS.some(
    ([a, b]) => (a === from && b === to) || (a === to && b === from)
  )
}

export function buildCorridorId(): string {
  const date   = new Date().toISOString().slice(0, 10).replace(/-/g, '')
  const suffix = Math.random().toString(36).slice(2, 6).toUpperCase()
  return `CRD-${date}-${suffix}`
}

/**
 * Build a two-step corridor quote.
 * Step 1: fromCurrency → USDC  (at fromRate)
 * Step 2: USDC → toCurrency    (at toRate)
 */
export function buildCorridorQuote(
  from:        Currency,
  to:          Currency,
  inputAmount: number,
  fromRate:    number,  // how many FROM units = 1 USDC
  toRate:      number,  // how many TO units = 1 USDC
): CorridorQuote {
  const corridorId = buildCorridorId()
  const now        = Math.floor(Date.now() / 1000)
  const deadline   = now + 600

  // Step 1: from → USDC
  const usdcFromStep1 = inputAmount / fromRate
  const spread1       = usdcFromStep1 * (SPREAD_BPS / 10_000)
  const netFee1       = 0.001
  const usdcAfterStep1 = usdcFromStep1 - spread1 - netFee1

  const step1: SwapQuote = {
    fromCurrency: from,
    toCurrency:   'USDC',
    fromAmount:   inputAmount,
    toAmount:     usdcAfterStep1,
    rate:         fromRate,
    spreadFee:    spread1,
    networkFee:   netFee1,
    deadline,
  }

  // Step 2: USDC → to  (using USDC received from step 1)
  const spread2        = usdcAfterStep1 * (SPREAD_BPS / 10_000)
  const netFee2        = 0.001
  const usdcForStep2   = usdcAfterStep1 - spread2 - netFee2
  const localReceived  = usdcForStep2 * toRate

  const step2: SwapQuote = {
    fromCurrency: 'USDC',
    toCurrency:   to,
    fromAmount:   usdcAfterStep1,
    toAmount:     localReceived,
    rate:         toRate,
    spreadFee:    spread2,
    networkFee:   netFee2,
    deadline,
  }

  return {
    corridorId,
    from,
    to,
    inputAmount,
    step1,
    step2,
    totalFee: spread1 + netFee1 + spread2 + netFee2,
    estimatedAt: now,
  }
}
