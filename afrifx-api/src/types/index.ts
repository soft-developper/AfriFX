export type Currency = 'USDC' | 'EURC' | 'NGN' | 'GHS' | 'KES' | 'ZAR' | 'EGP' | 'UGX' | 'TZS' | 'RWF' | 'XOF' | 'XAF' | 'ZMW' | 'ETB' | 'MZN'

// Single source of truth for the fiat currencies AfriFX supports (server-side).
// The rate oracle builds one <CUR>/USDC pair per entry, so adding a currency
// here is all it takes for its live rate to start flowing.
export const LOCAL_CURRENCIES: Currency[] = [
  'NGN', 'GHS', 'KES', 'ZAR', 'EGP',
  'UGX', 'TZS', 'RWF', 'XOF', 'XAF', 'ZMW', 'ETB', 'MZN',
]
export type TxStatus = 'pending' | 'settled' | 'failed'

export interface FXRate {
  pair:      string
  rate:      number
  change24h: number
  source:    string
  fetchedAt: number
}

export interface CreateTxBody {
  walletAddress: string
  fromCurrency:  Currency
  toCurrency:    Currency
  fromAmount:    number
  toAmount:      number
  spreadFee:     number
  networkFee:    number
  arcTxHash?:    string
}
