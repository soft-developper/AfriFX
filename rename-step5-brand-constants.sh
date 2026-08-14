#!/usr/bin/env bash
# ============================================================
# rename-step5-brand-constants.sh  —  AfriFX → Nexum, STEP 5: backend brand
#
# brand.ts routes user-visible brand strings through one place (by design).
# All fields are env-driven (process.env.X ?? fallback). Only ONE field is
# actually consumed: BRAND.name → the "Welcome to X" email subject (auth.ts:87).
#
# WHAT IT DOES — updates the code FALLBACKS (env still overrides):
#   name  'AfriFX'                     → 'Nexum'
#   slug  'afrifx'                     → 'nexum'
#   url   'https://afrifx.vercel.app'  → 'https://nexumpay.xyz'
#   supportEmail                       → LEFT AS-IS (unused; not touched)
#
# You will ALSO set on Render (env overrides fallbacks either way):
#   BRAND_NAME=Nexum   BRAND_SLUG=nexum   BRAND_URL=https://nexumpay.xyz
#
# Idempotent. Run from repo root:  cd ~/AfriFX && bash rename-step5-brand-constants.sh
# ============================================================
set -euo pipefail
ROOT="$(pwd)"; API="$ROOT/afrifx-api"
[ -d "$API" ] || { echo "ERROR: run from AfriFX repo root"; exit 1; }
BRAND="$API/src/lib/brand.ts"
[ -f "$BRAND" ] || { echo "ERROR: $BRAND not found"; exit 1; }

echo "→ Updating brand fallbacks (name, slug, url) — supportEmail left as-is…"

# name
if grep -q "process.env.BRAND_NAME ?? 'AfriFX'" "$BRAND"; then
  perl -0pi -e "s/process\.env\.BRAND_NAME \?\? 'AfriFX'/process.env.BRAND_NAME ?? 'Nexum'/" "$BRAND"
  echo "  ✓ name  → 'Nexum'"
else echo "  • name already updated (skip)"; fi

# slug
if grep -q "process.env.BRAND_SLUG ?? 'afrifx'" "$BRAND"; then
  perl -0pi -e "s/process\.env\.BRAND_SLUG \?\? 'afrifx'/process.env.BRAND_SLUG ?? 'nexum'/" "$BRAND"
  echo "  ✓ slug  → 'nexum'"
else echo "  • slug already updated (skip)"; fi

# url
if grep -q "process.env.BRAND_URL ?? 'https://afrifx.vercel.app'" "$BRAND"; then
  perl -0pi -e "s{process\.env\.BRAND_URL \?\? 'https://afrifx\.vercel\.app'}{process.env.BRAND_URL ?? 'https://nexumpay.xyz'}" "$BRAND"
  echo "  ✓ url   → 'https://nexumpay.xyz'"
else echo "  • url already updated (skip)"; fi

echo
echo "→ Verify (supportEmail must STILL be the old value — intentionally untouched):"
grep -nE "name:|slug:|url:|supportEmail:" "$BRAND"

echo
echo "Done (Step 5). Only downstream effect: 'Welcome to Nexum' email subject."
echo "Set on Render (optional but recommended): BRAND_NAME=Nexum BRAND_SLUG=nexum BRAND_URL=https://nexumpay.xyz"
echo "Next:"
echo "  cd afrifx-api && npx tsc --noEmit && npm run build && cd .."
echo "  git add -A && git commit -m 'rebrand(step5): backend brand fallbacks -> Nexum (env still overrides)' && git push"
