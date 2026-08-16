"use client"
// Searchable chain picker for the bridge — mirrors CurrencyCombobox.
// Reads the SAME cctpChains() registry the old <select> read, so routing,
// balances and execution are unchanged; this only improves selection UX now
// that the supported-chain list is long. Search matches chain name or key.
import { useState, useRef, useEffect, useMemo } from 'react'
import { cctpChains, chainByKey, type CctpChain } from '@/lib/cctp-chains'
import { ChevronDown, Search } from 'lucide-react'

export function ChainCombobox({
  value,
  onChange,
  disabled = false,
  exclude,
  placeholder = 'Search chain…',
}: {
  value: string
  onChange: (key: string) => void
  disabled?: boolean
  exclude?: string          // a chain key to hide (e.g. the other side of the route)
  placeholder?: string
}) {
  const [open, setOpen] = useState(false)
  const [query, setQuery] = useState('')
  const boxRef = useRef<HTMLDivElement>(null)

  const results = useMemo(() => {
    const q = query.trim().toLowerCase()
    return cctpChains().filter(c => {
      if (exclude && c.key === exclude) return false
      if (!q) return true
      return c.name.toLowerCase().includes(q) || c.key.toLowerCase().includes(q)
    })
  }, [query, exclude])

  useEffect(() => {
    function onDoc(e: MouseEvent) {
      if (boxRef.current && !boxRef.current.contains(e.target as Node)) setOpen(false)
    }
    document.addEventListener('mousedown', onDoc)
    return () => document.removeEventListener('mousedown', onDoc)
  }, [])

  const selected: CctpChain | undefined = chainByKey(value)

  return (
    <div ref={boxRef} className="relative">
      <button
        type="button"
        onClick={() => !disabled && setOpen(o => !o)}
        disabled={disabled}
        className="flex w-full items-center justify-between gap-2 rounded-lg border border-app-border bg-app-bg px-3 py-2.5 text-sm text-app-text outline-none hover:border-app-accent/50 disabled:opacity-50"
      >
        <span className="truncate font-medium">{selected?.name ?? 'Select chain'}</span>
        <ChevronDown className="h-4 w-4 shrink-0 text-app-muted" />
      </button>

      {open && !disabled && (
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
                No chain matches “{query}”.
              </li>
            )}
            {results.map(c => (
              <li key={c.key}>
                <button
                  type="button"
                  onClick={() => { onChange(c.key); setOpen(false); setQuery('') }}
                  className={`flex w-full items-center gap-2 px-3 py-2 text-left text-sm hover:bg-app-bg ${
                    c.key === value ? 'bg-app-bg' : ''
                  }`}
                >
                  <span className="font-medium text-app-text">{c.name}</span>
                  {c.isHome && <span className="ml-auto text-[10px] uppercase tracking-wide text-app-accent-text">home</span>}
                </button>
              </li>
            ))}
          </ul>
        </div>
      )}
    </div>
  )
}
