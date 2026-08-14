#!/usr/bin/env bash
# ============================================================
# rename-step6-env-keys.sh  —  AfriFX → Nexum, STEP 6: contract env keys
#
# RISK: NEXT_PUBLIC_AFRIFX_VAULT/_EXCHANGE feed CONTRACTS.AFRIFX_* (used by P2P,
# swap, corridor). If the code reads a NEW env name that Vercel doesn't have yet,
# it falls back to ZERO and those features silently break.
#
# SAFE DESIGN (no dashboard-timing risk):
#   • Rename the CODE key AFRIFX_VAULT→NEXUM_VAULT (+ 7 consumers). Internal only,
#     never leaves the bundle → zero deploy risk.
#   • Make the env READ accept BOTH names, new first, old fallback:
#       NEXT_PUBLIC_NEXUM_VAULT || NEXT_PUBLIC_AFRIFX_VAULT || ZERO
#     Next.js inlines NEXT_PUBLIC_* at build via LITERAL static access, so two
#     literal reads chained with || both get inlined. This keeps working with
#     the OLD Vercel vars untouched, AND picks up new vars whenever you add them.
#
# So you can add NEXT_PUBLIC_NEXUM_VAULT/_EXCHANGE to Vercel any time (or never);
# nothing breaks in the meantime. Later you can remove the AFRIFX_ vars + fallback.
#
# Idempotent. Run from repo root:  cd ~/AfriFX && bash rename-step6-env-keys.sh
# ============================================================
set -euo pipefail
ROOT="$(pwd)"; WEB="$ROOT/afrifx-web"
[ -d "$WEB" ] || { echo "ERROR: run from AfriFX repo root"; exit 1; }
cd "$WEB"

CONTRACTS="lib/contracts.ts"
[ -f "$CONTRACTS" ] || { echo "ERROR: $CONTRACTS not found"; exit 1; }

echo "→ 1/2  contracts.ts: rename keys + dual-name env read…"
if grep -q "NEXUM_VAULT" "$CONTRACTS"; then
  echo "  • already migrated (skip)"
else
  # Replace the two definition lines with renamed keys + fallback-chained reads.
  perl -0pi -e "s{  // AfriFX deployed contracts from \.env\.local\n  AFRIFX_VAULT:    \(process\.env\.NEXT_PUBLIC_AFRIFX_VAULT    \|\| ZERO\) as \`0x\\\$\{string\}\`,\n  AFRIFX_EXCHANGE: \(process\.env\.NEXT_PUBLIC_AFRIFX_EXCHANGE \|\| ZERO\) as \`0x\\\$\{string\}\`,}{  // Nexum deployed contracts from .env.local.\n  // Reads the NEXUM_ env first, falls back to the legacy AFRIFX_ env, so this\n  // works whether or not the new Vercel vars have been added yet.\n  NEXUM_VAULT:    (process.env.NEXT_PUBLIC_NEXUM_VAULT    || process.env.NEXT_PUBLIC_AFRIFX_VAULT    || ZERO) as \`0x\\\${string}\`,\n  NEXUM_EXCHANGE: (process.env.NEXT_PUBLIC_NEXUM_EXCHANGE || process.env.NEXT_PUBLIC_AFRIFX_EXCHANGE || ZERO) as \`0x\\\${string}\`,}s" "$CONTRACTS"
  if grep -q "NEXUM_VAULT:" "$CONTRACTS" && grep -q "NEXT_PUBLIC_AFRIFX_VAULT" "$CONTRACTS"; then
    echo "  ✓ keys renamed; env read accepts NEXUM_ then AFRIFX_ fallback"
  else echo "  ✗ contracts.ts anchor not matched"; exit 1; fi
fi

echo "→ 2/2  Updating the 7 consumers CONTRACTS.AFRIFX_* → CONTRACTS.NEXUM_*…"
mapfile -t FILES < <(grep -rlE "CONTRACTS\.AFRIFX_(VAULT|EXCHANGE)" --include=*.ts --include=*.tsx . 2>/dev/null | grep -vE "node_modules|\.next")
for f in "${FILES[@]}"; do
  perl -0pi -e "s/CONTRACTS\.AFRIFX_VAULT/CONTRACTS.NEXUM_VAULT/g; s/CONTRACTS\.AFRIFX_EXCHANGE/CONTRACTS.NEXUM_EXCHANGE/g;" "$f"
  echo "  ✓ $(echo "$f" | sed 's#^\./##')"
done

echo
echo "→ Verify: no CONTRACTS.AFRIFX_* consumers remain (should be empty):"
grep -rnE "CONTRACTS\.AFRIFX_(VAULT|EXCHANGE)" --include=*.ts --include=*.tsx . 2>/dev/null | grep -vE "node_modules|\.next" || echo "  ✓ none"
echo "→ Confirm legacy env fallback preserved (must still reference AFRIFX_ env):"
grep -n "NEXT_PUBLIC_AFRIFX_VAULT\|NEXT_PUBLIC_AFRIFX_EXCHANGE" "$CONTRACTS"

echo
echo "Done (Step 6). Works NOW with existing Vercel vars — no dashboard change required."
echo "When ready (optional), add to Vercel: NEXT_PUBLIC_NEXUM_VAULT, NEXT_PUBLIC_NEXUM_EXCHANGE"
echo "(same addresses). Later you can delete the AFRIFX_ vars + the fallback."
echo "Next:"
echo "  cd afrifx-web && rm -rf .next && npx tsc --noEmit && npm run build && cd .."
echo "  # smoke-test P2P/swap still load the vault address (not 0x000...0)"
echo "  git add -A && git commit -m 'rebrand(step6): contract keys AFRIFX_*→NEXUM_* with legacy env fallback' && git push"
