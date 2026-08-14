export type Currency = 'USDC' | 'EURC' | 'NGN' | 'GHS' | 'KES' | 'ZAR' | 'EGP' | 'UGX' | 'TZS' | 'RWF' | 'XOF' | 'XAF' | 'ZMW' | 'ETB' | 'MZN'

export interface FXRate {
  pair:      string
  rate:      number
  change24h: number
  source:    string
  fetchedAt: number
}

export interface SwapQuote {
  fromCurrency: Currency
  toCurrency:   Currency
  fromAmount:   number
  toAmount:     number
  rate:         number
  spreadFee:    number
  networkFee:   number
  deadline:     number
}

export interface CorridorQuote {
  corridorId:  string          // CRD-YYYYMMDD-XXXX
  from:        Currency
  to:          Currency
  inputAmount: number
  step1:       SwapQuote       // local → USDC
  step2:       SwapQuote       // USDC → local
  totalFee:    number          // combined spread + network fees
  estimatedAt: number
}

export interface Transaction {
  id:            string
  walletAddress: string
  fromCurrency:  Currency
  toCurrency:    Currency
  fromAmount:    number
  toAmount:      number
  spreadFee:     number
  networkFee:    number
  arcTxHash:     string | null
  memoId:        string | null
  reference:     string | null
  corridorId:    string | null  // links two-step corridor transactions
  corridorStep:  number | null  // 1 or 2
  status:        'pending' | 'settled' | 'failed'
  settledAt:     number | null
  createdAt:     number
}

export interface UserStats {
  walletAddress: string
  usdcBalance:   string
  volume30d:     number
  txCount:       number
}

export interface P2POffer {
  id:              string
  maker_address:   string
  taker_address:   string | null
  usdc_amount:     number
  local_currency:  string
  local_amount:    number
  rate_offered:    number
  status:          'open' | 'accepted' | 'released' | 'cancelled'
  maker_confirmed: number
  taker_confirmed: number
  arc_tx_hash:     string | null
  release_tx_hash: string | null
  expires_at:      number
  created_at:      number
  updated_at:      number
}

export interface UserProfile {
  wallet_address:  string
  username:        string
  display_name:    string
  bio:             string | null
  twitter_handle:  string | null
  telegram_handle: string | null
  avatar_color:    string
  trade_count:     number
  dispute_count:   number
  verified:        boolean
  show_socials:    boolean
  created_at:      number
  updated_at:      number
  maker_trades?:   number
  taker_trades?:   number
}
