export type Currency = 'USDC' | 'EURC' | 'NGN' | 'GHS' | 'KES' | 'ZAR' | 'EGP'
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
