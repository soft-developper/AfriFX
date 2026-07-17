'use client'
import { useFXRates } from '@/hooks/useFXRate'
import { TrendingUp, TrendingDown } from 'lucide-react'
import { CURRENCY_FLAG as FLAG } from '@/lib/corridor'

export function LandingRates() {
  const { data: rates, isLoading } = useFXRates()

  return (
    <div className="rounded-2xl border border-app-border bg-app-surface/60 p-4 backdrop-blur">
      <div className="mb-3 flex items-center justify-between px-1">
        <span className="text-xs font-medium uppercase tracking-wider text-app-muted">Live rates</span>
        <span className="flex items-center gap-1.5 text-xs text-app-muted">
          <span className="h-1.5 w-1.5 animate-pulse rounded-full bg-emerald-400" /> Updating
        </span>
      </div>

      {isLoading || !rates ? (
        <div className="grid grid-cols-2 gap-2 sm:grid-cols-3">
          {Array.from({ length: 6 }).map((_, i) => (
            <div key={i} className="h-14 animate-pulse rounded-xl bg-app-border/50" />
          ))}
        </div>
      ) : (
        // Cap the height to about two-and-a-half rows and let the rest scroll,
        // so the full 13-currency list doesn't dominate the hero. The custom
        // scrollbar keeps it subtle.
        <div className="grid max-h-[13rem] grid-cols-2 gap-2 overflow-y-auto pr-1 afx-scroll sm:grid-cols-3">
          {rates.map((r) => {
            const ccy = r.pair.split('/')[0]
            const up = (r.change24h ?? 0) >= 0
            return (
              <div key={r.pair} className="flex items-center justify-between rounded-xl bg-app-bg/60 px-3 py-2.5">
                <span className="flex items-center gap-2">
                  <span className="text-lg leading-none">{FLAG[ccy as keyof typeof FLAG] ?? '💱'}</span>
                  <span className="text-sm font-medium text-app-text">{r.pair}</span>
                </span>
                <span className="text-right">
                  <span className="block font-mono text-sm text-app-text">
                    {r.rate.toLocaleString(undefined, { maximumFractionDigits: 3 })}
                  </span>
                  <span className={`flex items-center justify-end gap-0.5 text-[10px] ${up ? 'text-emerald-400' : 'text-red-400'}`}>
                    {up ? <TrendingUp className="h-2.5 w-2.5" /> : <TrendingDown className="h-2.5 w-2.5" />}
                    {Math.abs(r.change24h ?? 0).toFixed(2)}%
                  </span>
                </span>
              </div>
            )
          })}
        </div>
      )}
    </div>
  )
}
