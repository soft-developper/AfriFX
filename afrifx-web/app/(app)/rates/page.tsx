'use client'
import { useFXRates } from '@/hooks/useFXRate'
import { TrendingUp, TrendingDown, RefreshCw } from 'lucide-react'

const FLAG: Record<string, string> = {
  NGN: '🇳🇬', GHS: '🇬🇭', KES: '🇰🇪',
  ZAR: '🇿🇦', EGP: '🇪🇬', EURC: '🇪🇺', USDC: '💵',
}

export default function RatesPage() {
  const { data: rates, isLoading, refetch } = useFXRates()

  return (
    <div>
      <div className="mb-6 flex items-center justify-between">
        <div>
          <h1 className="text-xl font-semibold text-app-text">Live rates</h1>
          <p className="text-sm text-app-muted">USDC settlement on Arc · refreshes every 30s</p>
        </div>
        <button
          onClick={() => refetch()}
          className="flex items-center gap-1.5 rounded-lg border border-app-border px-3 py-1.5 text-xs text-app-muted hover:text-app-text"
        >
          <RefreshCw className="h-3 w-3" /> Refresh
        </button>
      </div>

      {isLoading && <p className="text-sm text-app-muted">Fetching rates…</p>}

      <div className="space-y-2">
        {(rates ?? []).map((r) => {
          const [from] = r.pair.split('/')
          const up = r.change24h >= 0
          return (
            <div key={r.pair} className="flex items-center gap-4 rounded-xl border border-app-border bg-app-surface p-4">
              <span className="text-2xl">{FLAG[from] ?? '🌍'}</span>
              <div className="flex-1">
                <p className="text-sm font-medium text-app-text">{r.pair}</p>
                <p className="text-xs text-app-muted">Arc Testnet · USDC settlement</p>
              </div>
              <div className="text-right">
                <p className="font-mono text-lg font-medium text-app-text">{r.rate.toLocaleString()}</p>
                <p className={`flex items-center justify-end gap-0.5 text-xs ${up ? 'text-emerald-400' : 'text-red-400'}`}>
                  {up ? <TrendingUp className="h-3 w-3" /> : <TrendingDown className="h-3 w-3" />}
                  {up ? '+' : ''}{r.change24h.toFixed(2)}%
                </p>
              </div>
            </div>
          )
        })}
      </div>
    </div>
  )
}
