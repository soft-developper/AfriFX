#!/usr/bin/env bash
# ============================================================
# 2-bridge-chain-combobox.sh   (run once, then deploy web)
#
# Replaces the two plain <select> dropdowns in BridgeCard (From / To) with a
# searchable ChainCombobox, mirroring the CurrencyCombobox pattern already
# used on Create P2P Offer. With the chain list now ~9 long (and growing),
# a searchable picker is the same fix that worked for currencies.
#
# ARCHITECTURE MATCH:
#   - New component components/bridge/ChainCombobox.tsx follows the exact
#     structure of components/marketplace/CurrencyCombobox.tsx (button +
#     dropdown + search input + outside-click close), so it looks and behaves
#     identically.
#   - It reads the SAME cctpChains() registry the selects read, so nothing
#     about routing, balances, or execution changes — purely the picker UI.
#   - Search matches chain name OR key (e.g. "avax", "monad", "op").
#
# NOTE: no auto-scroll is used (list uses max-h + overflow-y-auto only),
# matching the stated UI preference.
# ============================================================
set -euo pipefail

if [ -d "nexum-web" ]; then WEB="nexum-web"
elif [ -d "$HOME/AfriFX/nexum-web" ]; then WEB="$HOME/AfriFX/nexum-web"
else echo "ERROR: run from repo root or ~/AfriFX"; exit 1; fi

COMPONENT="$WEB/components/bridge/ChainCombobox.tsx"
CARD="$WEB/components/bridge/BridgeCard.tsx"
[ -f "$CARD" ] || { echo "ERROR: $CARD not found"; exit 1; }
[ -f "$COMPONENT" ] && { echo "ERROR: $COMPONENT already exists — aborting to avoid overwrite"; exit 1; }

# ---------- (1) create ChainCombobox.tsx ----------
cat > "$COMPONENT" <<'TSX'
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
TSX
echo "Created $COMPONENT"

# ---------- (2) swap the two <select>s in BridgeCard.tsx ----------
PL="$(mktemp /tmp/bridgecard.XXXXXX.pl)"
cat > "$PL" <<'PERL'
use strict; use warnings;
local $/; my $f = shift; open my $fh,'<',$f or die $!; my $s=<$fh>; close $fh;

# add import after the cctp-chains import line, and drop now-unused cctpChains.
# chainByKey + isRouteSupported stay used; cctpChains is only used by the
# `const chains` line we remove below, so trim it to keep the strict build green.
my $imp_old = "import { cctpChains, chainByKey, isRouteSupported } from '\@/lib/cctp-chains'";
my $imp_new = "import { chainByKey, isRouteSupported } from '\@/lib/cctp-chains'\nimport { ChainCombobox } from '\@/components/bridge/ChainCombobox'";
my $c = () = $s =~ /\Q$imp_old\E/g; die "cctp import anchor: found $c\n" unless $c==1;
$s =~ s/\Q$imp_old\E/$imp_new/;

# remove the now-unused `const chains = cctpChains()` line
my $ch_old = "  const chains = cctpChains()\n";
$c = () = $s =~ /\Q$ch_old\E/g; die "const chains anchor: found $c\n" unless $c==1;
$s =~ s/\Q$ch_old\E//;

# From select -> ChainCombobox
my $from_old = "      <select\n        value={fromKey}\n        onChange={e => setFromKey(e.target.value)}\n        disabled={busy}\n        className=\"mb-3 w-full rounded-lg border border-app-border bg-app-bg px-3 py-2.5 text-sm text-app-text outline-none disabled:opacity-50\"\n      >\n        {chains.map(c => <option key={c.key} value={c.key}>{c.name}</option>)}\n      </select>";
my $from_new = "      <div className=\"mb-3\">\n        <ChainCombobox value={fromKey} onChange={setFromKey} disabled={busy} exclude={toKey} />\n      </div>";
$c = () = $s =~ /\Q$from_old\E/g; die "From select anchor: found $c\n" unless $c==1;
$s =~ s/\Q$from_old\E/$from_new/;

# To select -> ChainCombobox
my $to_old = "      <select\n        value={toKey}\n        onChange={e => setToKey(e.target.value)}\n        disabled={busy}\n        className=\"mb-3 w-full rounded-lg border border-app-border bg-app-bg px-3 py-2.5 text-sm text-app-text outline-none disabled:opacity-50\"\n      >\n        {chains.map(c => <option key={c.key} value={c.key}>{c.name}</option>)}\n      </select>";
my $to_new = "      <div className=\"mb-3\">\n        <ChainCombobox value={toKey} onChange={setToKey} disabled={busy} exclude={fromKey} />\n      </div>";
$c = () = $s =~ /\Q$to_old\E/g; die "To select anchor: found $c\n" unless $c==1;
$s =~ s/\Q$to_old\E/$to_new/;

open my $out,'>',$f or die $!; print $out $s; close $out;
print "BridgeCard.tsx: both selects -> ChainCombobox.\n";
PERL
perl "$PL" "$CARD"; rm -f "$PL"

echo
echo "Verify:"
grep -n "ChainCombobox" "$CARD" | sed 's/^/  /'
if grep -q "<select" "$CARD"; then echo "  !! a <select> still remains in BridgeCard"; else echo "  no <select> left in BridgeCard."; fi
echo
echo "Deploy:"
echo "  cd $WEB && rm -rf .next && npx tsc --noEmit && npm run build"
echo "  git add -A && git commit -m 'feat(bridge): searchable chain picker' && git push"
