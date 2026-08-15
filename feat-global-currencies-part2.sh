#!/usr/bin/env bash
# ============================================================
# feat-global-currencies-part2.sh — searchable currency combobox (offer creation)
#
# Part 2 of the P2P global expansion (Part 1 = data foundation).
#   1. Adds components/marketplace/CurrencyCombobox.tsx — a searchable picker.
#      Availability from the LIVE rate feed (only currencies with a rate show —
#      the "hide untracked" behavior); metadata + search from the ISO registry
#      (lib/currencies.ts). Search by currency code OR country name.
#   2. Swaps the plain <select> in CreateOfferClient for the combobox.
#
# Requires Part 1 (lib/currencies.ts + widened /rates) already deployed.
# Idempotent. Run from repo root:  cd ~/AfriFX && bash feat-global-currencies-part2.sh
# ============================================================
set -euo pipefail
ROOT="$(pwd)"
WEB="$ROOT/nexum-web"; [ -d "$WEB" ] || WEB="$ROOT/afrifx-web"
[ -d "$WEB" ] || { echo "ERROR: run from repo root"; exit 1; }
cd "$WEB"

[ -f lib/currencies.ts ] || { echo "ERROR: lib/currencies.ts missing — run Part 1 first"; exit 1; }
CO="app/(app)/marketplace/create/CreateOfferClient.tsx"
[ -f "$CO" ] || { echo "ERROR: $CO not found"; exit 1; }

echo "→ 1/2  Writing components/marketplace/CurrencyCombobox.tsx…"
mkdir -p components/marketplace
if [ -f components/marketplace/CurrencyCombobox.tsx ]; then
  echo "  • already exists (skip)"
else
  cat > components/marketplace/CurrencyCombobox.tsx <<'COMBOBOX_EOF'
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
}: {
  value: string
  onChange: (code: string) => void
  placeholder?: string
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
    return set
  }, [rates])

  // Available = live ∩ registry, filtered by the search query.
  const results = useMemo(() => {
    const matches = searchCurrencies(query)
    return matches.filter(m => liveCodes.has(m.code))
  }, [query, liveCodes])

  // Close on outside click.
  useEffect(() => {
    function onDoc(e: MouseEvent) {
      if (boxRef.current && !boxRef.current.contains(e.target as Node)) setOpen(false)
    }
    document.addEventListener('mousedown', onDoc)
    return () => document.removeEventListener('mousedown', onDoc)
  }, [])

  const selected: CurrencyMeta | undefined = CURRENCY_BY_CODE[value]

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
COMBOBOX_EOF
  echo "  ✓ CurrencyCombobox.tsx written"
fi

echo "→ 2/2  Swapping the <select> for the combobox in CreateOfferClient…"
if grep -q "CurrencyCombobox" "$CO"; then
  echo "  • already using combobox (skip)"
else
  # add the import (after the corridor import line)
  perl -0pi -e "s{(import \{ LOCAL_CURRENCIES as CURRENCIES, CURRENCY_FLAG \} from '\@/lib/corridor'\n)}{\$1import { CurrencyCombobox } from '\@/components/marketplace/CurrencyCombobox'\n}" "$CO"

  # replace the <select>…</select> block with the combobox
  perl -0pi -e "s{<select value=\{localCurrency\} onChange=\{\(e\) => setLocalCurrency\(e\.target\.value\)\}\n\s*className=\"rounded-lg border border-app-border bg-app-bg px-3 py-2 text-sm text-app-text outline-none\">\n\s*\{CURRENCIES\.map\(c => \(\n\s*<option key=\{c\} value=\{c\}>\{CURRENCY_FLAG\[c\]\} \{c\}</option>\n\s*\)\)\}\n\s*</select>}{<div className=\"min-w-\[11rem\]\">\n              <CurrencyCombobox value={localCurrency} onChange={setLocalCurrency} />\n            </div>}s" "$CO"

  if grep -q "<CurrencyCombobox value={localCurrency}" "$CO"; then
    echo "  ✓ combobox swapped in"
    # The corridor import (CURRENCIES/CURRENCY_FLAG) is now unused in this file.
    if ! grep -qE "\bCURRENCIES\b|\bCURRENCY_FLAG\b" <(grep -v "^import" "$CO"); then
      perl -0pi -e "s{import \{ LOCAL_CURRENCIES as CURRENCIES, CURRENCY_FLAG \} from '\@/lib/corridor'\n}{}" "$CO"
      echo "  - removed now-unused corridor import"
    fi
  else
    echo "  ✗ <select> block not matched — the markup may differ; review $CO"; exit 1
  fi
fi

echo
echo "→ Verify:"
grep -n "CurrencyCombobox" "$CO"
echo "  (CURRENCIES/CURRENCY_FLAG imports may now be unused in this file — harmless,"
echo "   but tsc with noUnusedLocals could flag them. Checking…)"
grep -nE "CURRENCIES|CURRENCY_FLAG" "$CO" | grep -v "import" | head

echo
echo "Done (Part 2). Next:"
echo "  cd $(basename "$WEB") && rm -rf .next && npx tsc --noEmit && npm run build && cd .."
echo "  # test: open Create Offer → currency picker → type 'Nigeria' or 'JPY' → select"
echo "  git add -A && git commit -m 'feat(p2p): searchable currency combobox in offer creation (part 2)' && git push"
