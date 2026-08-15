#!/usr/bin/env bash
# ============================================================
# fix-rates-undefined-crash.sh
#
# CRASH: "Cannot read properties of undefined (reading 'toLocaleString')" in a
# .map — the rate ticker/rates pages do r.rate.toLocaleString(). After Part 1
# widened LOCAL_CURRENCIES to ~178, buildRates emits { rate: undefined } for any
# currency the live feed lacks AND that isn't in the small HARDCODED fallback.
# undefined.toLocaleString() → crash.
#
# FIX (two layers):
#   A) BACKEND (root cause): buildRates OMITS pairs with no usable rate — this is
#      exactly the intended "hide untracked" behavior. Only real rates ship.
#   B) FRONTEND (defense in depth): rate displays filter out rateless entries and
#      guard .toLocaleString so a bad entry can never hard-crash the UI again.
#
# Idempotent. Run from repo root:  cd ~/AfriFX && bash fix-rates-undefined-crash.sh
# ============================================================
set -euo pipefail
ROOT="$(pwd)"
WEB="$ROOT/nexum-web"; [ -d "$WEB" ] || WEB="$ROOT/afrifx-web"
API="$ROOT/nexum-api"; [ -d "$API" ] || API="$ROOT/afrifx-api"
[ -d "$WEB" ] && [ -d "$API" ] || { echo "ERROR: run from repo root"; exit 1; }

echo "→ 1/2  BACKEND: buildRates omits pairs with no usable rate…"
RO="$API/src/services/rateOracle.ts"
[ -f "$RO" ] || { echo "ERROR: $RO not found"; exit 1; }
if grep -q "filter(r => r.rate" "$RO"; then
  echo "  • already filtered (skip)"
else
  # change the .map to compute rate, then filter out undefined/null/NaN before returning
  perl -0pi -e "s{  const rates: FXRate\[\] = LOCAL_CURRENCIES\.map\(cur => \{\n    const rate = raw\[cur\] \?\? HARDCODED\[cur\]\n    const pair = \`\\\$\{cur\}/USDC\`\n    return \{ pair, rate, change24h: pct\(prev\[pair\], rate\), source, fetchedAt: now \}\n  \}\)}{  const rates: FXRate[] = LOCAL_CURRENCIES\n    .map(cur => {\n      const rate = raw[cur] ?? HARDCODED[cur]\n      const pair = \`\\\${cur}/USDC\`\n      return { pair, rate, change24h: pct(prev[pair], rate), source, fetchedAt: now }\n    })\n    // Omit currencies with no usable rate — \"hide untracked\": a currency only\n    // appears if the feed (or HARDCODED fallback) actually has a value for it.\n    .filter(r => typeof r.rate === 'number' && isFinite(r.rate) && r.rate > 0)}s" "$RO"
  grep -q "filter(r => typeof r.rate" "$RO" && echo "  ✓ rateless pairs now omitted" || { echo "  ✗ buildRates anchor not matched"; exit 1; }
fi

echo "→ 2/2  FRONTEND: guard rate displays against undefined…"
guard_file() {
  local f="$1"; local desc="$2"
  [ -f "$f" ] || { echo "  • $desc not found (skip)"; return; }
  # (i) guard the .toLocaleString call: r.rate.toLocaleString → (r.rate ?? 0).toLocaleString
  perl -0pi -e "s/\br\.rate\.toLocaleString\(/(r.rate ?? 0).toLocaleString(/g" "$f"
  echo "  ✓ $desc"
}
guard_file "$WEB/components/layout/TickerStrip.tsx"        "TickerStrip"
guard_file "$WEB/components/landing/LandingRates.tsx"      "LandingRates"
guard_file "$WEB/app/(app)/rates/page.tsx"                 "rates page"

# Extra safety: in the three files, also filter the array before mapping so
# rateless rows don't render blank. Only where a simple .map(r => exists.
for f in "$WEB/components/layout/TickerStrip.tsx" "$WEB/components/landing/LandingRates.tsx" "$WEB/app/(app)/rates/page.tsx"; do
  [ -f "$f" ] || continue
  # add a defensive .filter on the rates array right after useFXRates data usage,
  # only if not already present
  grep -q "rate != null" "$f" || perl -0pi -e "s/\(rates \?\? \[\]\)\.map\(/(rates ?? []).filter((r: any) => r \&\& r.rate != null).map(/g" "$f"
done

echo
echo "→ Verify:"
grep -n "filter(r => typeof r.rate" "$RO" | head -1
grep -rn "(r.rate ?? 0).toLocaleString" "$WEB/components/layout/TickerStrip.tsx" "$WEB/components/landing/LandingRates.tsx" "$WEB/app/(app)/rates/page.tsx" 2>/dev/null | head

echo
echo "Done. Crash fixed at both layers. Next:"
echo "  cd $(basename "$API") && npx tsc --noEmit && npm run build && cd .."
echo "  cd $(basename "$WEB") && rm -rf .next && npx tsc --noEmit && npm run build && cd .."
echo "  git add -A && git commit -m 'fix(rates): omit rateless pairs (backend) + guard toLocaleString (frontend)' && git push"
