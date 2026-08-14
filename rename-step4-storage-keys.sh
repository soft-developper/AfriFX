#!/usr/bin/env bash
# ============================================================
# rename-step4-storage-keys.sh  —  AfriFX → Nexum, STEP 4: storage keys
#
# RISK: renaming storage keys naively logs out EVERY current user & admin and
# resets themes on deploy (new code reads a key their browser doesn't have).
#
# FIX: a one-time, pre-hydration migration copies each OLD key's value to the
# NEW key and deletes the OLD one, so existing sessions carry over seamlessly.
#
# Keys (mechanism · value):
#   afrifx_token        localStorage  raw   → nexum_token
#   afrifx_account      localStorage  JSON  → nexum_account
#   afrifx_admin_token  sessionStorage raw  → nexum_admin_token
#   afrifx_admin        sessionStorage JSON → nexum_admin
#   afrifx_theme        localStorage  raw   → nexum_theme
#
# WHAT IT DOES:
#   1. Injects a migration block into layout.tsx's pre-hydration inline script,
#      so keys are moved BEFORE any hook (useAuth/useAdminAuth/useTheme) reads.
#   2. Updates that script's theme read to check NEW then OLD (no flash on the
#      first post-deploy load).
#   3. Renames the key CONSTANTS in the 3 hooks to nexum_*.
#
# Idempotent. Run from repo root:  cd ~/AfriFX && bash rename-step4-storage-keys.sh
# ============================================================
set -euo pipefail
ROOT="$(pwd)"; WEB="$ROOT/afrifx-web"
[ -d "$WEB" ] || { echo "ERROR: run from AfriFX repo root"; exit 1; }
cd "$WEB"

LAYOUT="app/layout.tsx"
AUTH="hooks/useAuth.ts"
ADMIN="hooks/useAdminAuth.ts"
THEME="hooks/useTheme.tsx"
for f in "$LAYOUT" "$AUTH" "$ADMIN" "$THEME"; do [ -f "$f" ] || { echo "ERROR: missing $f"; exit 1; }; done

echo "→ 1/3  Injecting one-time key migration into the pre-hydration script…"
if grep -q "nexum_token" "$LAYOUT"; then
  echo "  • migration already present (skip)"
else
  # Insert the migration + dual-read theme logic at the top of the IIFE body.
  perl -0pi -e "s/(const themeInitScript = \`\n\(function\(\) \{\n  try \{\n)/\$1    \/\/ ── AfriFX→Nexum one-time storage-key migration (runs before hooks) ──\n    \/\/ Move each old key's value to the new name, then drop the old key. Runs\n    \/\/ once: after the first load the old keys are gone and this no-ops.\n    var LS = [['afrifx_token','nexum_token'],['afrifx_account','nexum_account'],['afrifx_theme','nexum_theme']];\n    for (var i=0;i<LS.length;i++){var o=LS[i][0],n=LS[i][1];try{if(localStorage.getItem(n)===null){var v=localStorage.getItem(o);if(v!==null){localStorage.setItem(n,v);localStorage.removeItem(o);}}}catch(e){}}\n    var SS = [['afrifx_admin_token','nexum_admin_token'],['afrifx_admin','nexum_admin']];\n    for (var j=0;j<SS.length;j++){var so=SS[j][0],sn=SS[j][1];try{if(sessionStorage.getItem(sn)===null){var sv=sessionStorage.getItem(so);if(sv!==null){sessionStorage.setItem(sn,sv);sessionStorage.removeItem(so);}}}catch(e){}}\n/s" "$LAYOUT"
  # Update the theme read to new key (migration above already moved it)
  perl -0pi -e "s/var stored = localStorage.getItem\('afrifx_theme'\);/var stored = localStorage.getItem('nexum_theme');/s" "$LAYOUT"
  if grep -q "nexum_token" "$LAYOUT" && grep -q "getItem('nexum_theme')" "$LAYOUT"; then
    echo "  ✓ migration + theme read injected into layout.tsx"
  else echo "  ✗ layout.tsx injection failed"; exit 1; fi
fi

echo "→ 2/3  Renaming key constants in the 3 hooks…"
perl -0pi -e "s/'afrifx_token'/'nexum_token'/;         s/'afrifx_account'/'nexum_account'/;" "$AUTH"
perl -0pi -e "s/'afrifx_admin_token'/'nexum_admin_token'/; s/'afrifx_admin'/'nexum_admin'/;" "$ADMIN"
perl -0pi -e "s/'afrifx_theme'/'nexum_theme'/" "$THEME"
echo "  ✓ constants updated"

echo "→ 3/3  Verify…"
echo "  hooks now use nexum_*:"
grep -nE "'nexum_token'|'nexum_account'|'nexum_admin_token'|'nexum_admin'|'nexum_theme'" "$AUTH" "$ADMIN" "$THEME"
echo "  no stray old key literals remain (should be empty):"
STRAY=$(grep -rnE "'afrifx_token'|'afrifx_account'|'afrifx_admin_token'|'afrifx_admin'|'afrifx_theme'" --include=*.ts --include=*.tsx . 2>/dev/null | grep -vE "node_modules|\.next" | grep -vE "layout.tsx" || true)
# layout.tsx legitimately still contains the OLD names inside the migration array
if [ -z "$STRAY" ]; then echo "    ✓ none outside the migration block"; else echo "    ⚠ review:"; echo "$STRAY"; fi

echo
echo "Done (Step 4). Existing users/admins stay logged in; themes preserved."
echo "Next:"
echo "  cd afrifx-web && rm -rf .next && npx tsc --noEmit && npm run build && cd .."
echo "  # TEST logged-in: sign in on OLD build, deploy, reload → still signed in,"
echo "  #   and in DevTools>Application, nexum_token exists / afrifx_token is gone."
echo "  git add -A && git commit -m 'rebrand(step4): migrate storage keys afrifx_*→nexum_* (no logout)' && git push"
