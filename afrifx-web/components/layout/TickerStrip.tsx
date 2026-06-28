'use client'
import { useFXRates } from '@/hooks/useFXRate'

const FALLBACK = [
  { pair: 'NGN/USDC', rate: 1600,  change24h: +0.42 },
  { pair: 'GHS/USDC', rate: 14.2,  change24h: -0.18 },
  { pair: 'KES/USDC', rate: 129.5, change24h: +0.11 },
  { pair: 'ZAR/USDC', rate: 18.3,  change24h: -0.05 },
  { pair: 'EGP/USDC', rate: 48.7,  change24h: +0.29 },
]

export function TickerStrip() {
  const { data: rates } = useFXRates()
  const items = (rates ?? FALLBACK).concat(rates ?? FALLBACK) // doubled for seamless loop

  return (
    <div className="overflow-hidden border-b border-[#1B2B4B] bg-[#0F1729] py-1.5">
      <div className="flex w-max animate-[ticker_30s_linear_infinite] gap-8 whitespace-nowrap">
        {items.map((r, i) => {
          const up = r.change24h >= 0
          return (
            <span key={i} className="inline-flex items-center gap-2 text-xs">
              <span className="font-medium text-[#E2E8F0]">{r.pair}</span>
              <span className="font-mono text-[#E2E8F0]">{r.rate.toLocaleString()}</span>
              <span className={up ? 'text-emerald-400' : 'text-red-400'}>
                {up ? '+' : ''}{r.change24h.toFixed(2)}%
              </span>
            </span>
          )
        })}
      </div>
    </div>
  )
}
