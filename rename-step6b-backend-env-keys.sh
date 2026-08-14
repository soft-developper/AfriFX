#!/usr/bin/env bash
# ============================================================
# rename-step6b-backend-env-keys.sh  —  AfriFX → Nexum, STEP 6B: BACKEND env keys
#
# The API reads AFRIFX_VAULT_ADDRESS (Render env) in platformWallet.ts to call
# releaseP2POffer/cancelP2POffer — i.e. it MOVES real USDC on P2P settlement and
# disputes. If this read breaks, P2P release/cancel fail with "not set".
#
# SAFE DESIGN (no dashboard-timing risk): dual-name read, old as fallback:
#   process.env.NEXUM_VAULT_ADDRESS || process.env.AFRIFX_VAULT_ADDRESS
# Backend reads process.env at RUNTIME, so this works with the CURRENT Render var
# (AFRIFX_) untouched, and also picks up NEXUM_ whenever you add it.
#
# NOTE: AFRIFX_EXCHANGE_ADDRESS exists on Render but is NOT referenced in code —
# it's a dead env var. Nothing to change here; you can delete it on Render later.
#
# Idempotent. Run from repo root:  cd ~/AfriFX && bash rename-step6b-backend-env-keys.sh
# ============================================================
set -euo pipefail
ROOT="$(pwd)"; API="$ROOT/afrifx-api"
[ -d "$API" ] || { echo "ERROR: run from AfriFX repo root"; exit 1; }
PW="$API/src/services/platformWallet.ts"
[ -f "$PW" ] || { echo "ERROR: $PW not found"; exit 1; }

echo "→ platformWallet.ts: dual-name read + clearer error messages…"
if grep -q "NEXUM_VAULT_ADDRESS" "$PW"; then
  echo "  • already migrated (skip)"
else
  # 1) the read: accept NEXUM_ then AFRIFX_ fallback
  perl -0pi -e "s{const VAULT_ADDRESS = process\.env\.AFRIFX_VAULT_ADDRESS as \`0x\\\$\{string\}\`}{const VAULT_ADDRESS = (process.env.NEXUM_VAULT_ADDRESS || process.env.AFRIFX_VAULT_ADDRESS) as \`0x\\\${string}\`}" "$PW"
  # 2) both error messages: mention both env names
  perl -0pi -e "s/throw new Error\('AFRIFX_VAULT_ADDRESS not set in \.env'\)/throw new Error('Vault address not set: set NEXUM_VAULT_ADDRESS (or legacy AFRIFX_VAULT_ADDRESS) in .env')/g" "$PW"

  if grep -q "NEXUM_VAULT_ADDRESS ||" "$PW" && ! grep -q "'AFRIFX_VAULT_ADDRESS not set in .env'" "$PW"; then
    echo "  ✓ read now NEXUM_ || AFRIFX_ ; error messages updated"
  else echo "  ✗ anchor(s) not matched — review $PW"; exit 1; fi
fi

echo
echo "→ Verify:"
grep -n "VAULT_ADDRESS = \|NEXUM_VAULT_ADDRESS\|AFRIFX_VAULT_ADDRESS" "$PW"

echo
echo "Done (Step 6B). Works NOW with the existing Render AFRIFX_VAULT_ADDRESS."
echo "When ready (optional), add to Render: NEXUM_VAULT_ADDRESS (same address)."
echo "Also on Render: AFRIFX_EXCHANGE_ADDRESS is unused by code — safe to delete anytime."
echo "Next:"
echo "  cd afrifx-api && npx tsc --noEmit && npm run build && cd .."
echo "  # smoke: a P2P release/cancel path should still resolve the vault (no 'not set' error)"
echo "  git add -A && git commit -m 'rebrand(step6b): backend vault env AFRIFX_→NEXUM_ with legacy fallback' && git push"
