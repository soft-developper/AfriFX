"use client"
// Searchable currency picker for the global marketplace.
// AVAILABILITY comes from the LIVE rate feed (only currencies with a rate show),
// METADATA (flag, country, search) comes from the ISO registry. Search matches
// currency code, currency name, or any country that uses it.
import { useState, useRef, useEffect, useMemo } from 'react'
import { useFXRates } from '@/hooks/useFXRate'
import { CURRENCY_BY_CODE, searchCurrencies, type CurrencyMeta } from '@/lib/currencies'
import { ChevronDown, Search } from 'lucide-react'

export function CurrencyCombobox({
  value,
  onChange,
  placeholder = 'Search country or currency…',
  includeUsdc = false,
}: {
  value: string
  onChange: (code: string) => void
  placeholder?: string
  includeUsdc?: boolean
}) {
  const { data: rates } = useFXRates()
  const [open, setOpen] = useState(false)
  const [query, setQuery] = useState('')
  const boxRef = useRef<HTMLDivElement>(null)

  // Currency codes that actually have a live rate (pairs look like "NGN/USDC").
  const liveCodes = useMemo(() => {
    const set = new Set<string>()
    for (const r of rates ?? []) {
      const code = r.pair.split('/')[0]
      if (code) set.add(code)
    }
    if (includeUsdc) set.add('USDC')
    return set
  }, [rates, includeUsdc])

  // Available = live ∩ registry, filtered by the search query.
  const USDC_META: CurrencyMeta = {
    code: 'USDC', name: 'USD Coin', country: 'Stablecoin', flag: '💵', countries: ['USDC'],
  }

  const results = useMemo(() => {
    const matches = searchCurrencies(query)
    const base = matches.filter(m => liveCodes.has(m.code))
    if (!includeUsdc) return base
    const q = query.trim().toLowerCase()
    const usdcMatches = !q || 'usdc'.includes(q) || 'usd coin'.includes(q) || 'stablecoin'.includes(q)
    // USDC first, and never duplicated if the registry ever adds it.
    const withoutUsdc = base.filter(m => m.code !== 'USDC')
    return usdcMatches ? [USDC_META, ...withoutUsdc] : withoutUsdc
  }, [query, liveCodes, includeUsdc])

  // Close on outside click.
  useEffect(() => {
    function onDoc(e: MouseEvent) {
      if (boxRef.current && !boxRef.current.contains(e.target as Node)) setOpen(false)
    }
    document.addEventListener('mousedown', onDoc)
    return () => document.removeEventListener('mousedown', onDoc)
  }, [])

  const selected: CurrencyMeta | undefined =
    CURRENCY_BY_CODE[value] ?? (value === 'USDC' ? USDC_META : undefined)

  return (
    <div ref={boxRef} className="relative">
      <button
        type="button"
        onClick={() => setOpen(o => !o)}
        className="flex w-full items-center justify-between gap-2 rounded-lg border border-app-border bg-app-bg px-3 py-2 text-sm text-app-text outline-none hover:border-app-accent/50"
      >
        <span className="flex items-center gap-2 truncate">
          <span className="text-base">{selected?.flag ?? '🌍'}</span>
          <span className="font-medium">{value || 'Select'}</span>
          {selected && <span className="truncate text-xs text-app-muted">{selected.country}</span>}
        </span>
        <ChevronDown className="h-4 w-4 shrink-0 text-app-muted" />
      </button>

      {open && (
        <div className="absolute z-50 mt-1 w-full rounded-lg border border-app-border bg-app-surface shadow-lg">
          <div className="flex items-center gap-2 border-b border-app-border px-3 py-2">
            <Search className="h-3.5 w-3.5 text-app-muted" />
            <input
              autoFocus
              value={query}
              onChange={e => setQuery(e.target.value)}
              placeholder={placeholder}
              className="w-full bg-transparent text-sm text-app-text outline-none placeholder:text-app-muted"
            />
          </div>
          <ul className="max-h-64 overflow-y-auto py-1">
            {results.length === 0 && (
              <li className="px-3 py-3 text-center text-xs text-app-muted">
                No tracked currency matches “{query}”.
              </li>
            )}
            {results.map(c => (
              <li key={c.code}>
                <button
                  type="button"
                  onClick={() => { onChange(c.code); setOpen(false); setQuery('') }}
                  className={`flex w-full items-center gap-2 px-3 py-2 text-left text-sm hover:bg-app-bg ${
                    c.code === value ? 'bg-app-bg' : ''
                  }`}
                >
                  <span className="text-base">{c.flag}</span>
                  <span className="font-medium text-app-text">{c.code}</span>
                  <span className="truncate text-xs text-app-muted">{c.country}</span>
                </button>
              </li>
            ))}
          </ul>
        </div>
      )}
    </div>
  )
}
