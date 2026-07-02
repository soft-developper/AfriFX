'use client'
import { Badge } from '@/components/ui/badge'
import { Zap, RefreshCw } from 'lucide-react'
import { formatAmount } from '@/lib/utils'
import { SPREAD_BPS } from '@/lib/contracts'
import type { Currency } from '@/types'

interface RateDisplayProps {
  fromCurrency: Currency
  toCurrency: Currency
  rate: number
  spreadFee: number
  networkFee: number
  isLoading?: boolean
}

export function RateDisplay({ fromCurrency, toCurrency, rate, spreadFee, networkFee, isLoading }: RateDisplayProps) {
  if (isLoading) {
    return (
      <div className="flex items-center justify-center gap-2 py-2 text-xs text-app-muted">
        <RefreshCw className="h-3 w-3 animate-spin" /> Fetching rate…
      </div>
    )
  }

  return (
    <div className="space-y-1.5 border-t border-app-border pt-3">
      <div className="flex items-center justify-between text-xs">
        <span className="text-app-muted">Rate</span>
        <span className="font-mono text-app-text">
          1 {toCurrency} = {fromCurrency !== 'USDC' ? formatAmount(rate, 0) : formatAmount(1 / rate, 4)} {fromCurrency}
        </span>
      </div>
      <div className="flex items-center justify-between text-xs">
        <span className="text-app-muted">AfriFX spread ({SPREAD_BPS / 100}%)</span>
        <span className="font-mono text-app-text">${formatAmount(spreadFee, 4)} USDC</span>
      </div>
      <div className="flex items-center justify-between text-xs">
        <span className="text-app-muted">Network fee</span>
        <Badge variant="arc" className="gap-1">
          <Zap className="h-2.5 w-2.5" /> ~${networkFee} USDC
        </Badge>
      </div>
      <div className="flex items-center justify-between text-xs font-medium">
        <span className="text-app-muted">Settlement</span>
        <span className="text-emerald-400">Instant · Arc chain</span>
      </div>
    </div>
  )
}
