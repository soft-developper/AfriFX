#!/usr/bin/env bash
# ============================================================
# fix-build-timeout.sh — fix CI web build failure (static gen timeout)
#
# ROOT CAUSE: /about and /contact fetch ${NEXT_PUBLIC_API_URL}/content/... at
# BUILD time. Two problems compounded:
#   (a) rename-step7 wrongly rewrote ci.yml's NEXT_PUBLIC_API_URL to the
#       non-existent nexum-api.onrender.com (the Render URL never changed —
#       only the service's root directory did). Fetch to a dead domain HANGS.
#   (b) the fetch has no timeout, so a hang isn't caught by the try/catch —
#       Next kills the worker after 60s and the build fails.
#
# FIXES:
#   1. ci.yml: NEXT_PUBLIC_API_URL back to afrifx-api.onrender.com (real URL).
#   2. about/contact: add AbortSignal.timeout(8000) so a slow/dead API aborts
#      fast → falls into existing catch → renders the graceful empty state.
#      Build no longer depends on a live API. (This is the important fix.)
#
# Run from repo root:  cd ~/AfriFX && bash fix-build-timeout.sh
# ============================================================
set -euo pipefail
ROOT="$(pwd)"; WEB="$ROOT/nexum-web"; CI="$ROOT/.github/workflows/ci.yml"
[ -d "$WEB" ] || { echo "ERROR: run from repo root (nexum-web not found)"; exit 1; }

echo "→ 1/3  ci.yml: restore real API URL (undo the bad rename)…"
if [ -f "$CI" ] && grep -q "NEXT_PUBLIC_API_URL: https://nexum-api.onrender.com" "$CI"; then
  perl -0pi -e "s{NEXT_PUBLIC_API_URL: https://nexum-api\.onrender\.com}{NEXT_PUBLIC_API_URL: https://afrifx-api.onrender.com}" "$CI"
  echo "  ✓ CI NEXT_PUBLIC_API_URL → afrifx-api.onrender.com"
else
  echo "  • ci.yml already correct or not in expected form (skip)"
fi

echo "→ 2/3  about/page.tsx: add fetch timeout so build can't hang…"
AB="$WEB/app/about/page.tsx"
if grep -q "AbortSignal.timeout" "$AB"; then
  echo "  • already has timeout (skip)"
else
  perl -0pi -e "s{const res = await fetch\(\`\\\$\{API\}/content/about\`, \{ next: \{ revalidate: 60 \} \}\)}{const res = await fetch(\`\\\${API}/content/about\`, { next: { revalidate: 60 }, signal: AbortSignal.timeout(8000) })}" "$AB"
  grep -q "AbortSignal.timeout" "$AB" && echo "  ✓ about fetch now times out after 8s" || { echo "  ✗ about anchor not matched"; exit 1; }
fi

echo "→ 3/3  contact/page.tsx: add fetch timeout…"
CT="$WEB/app/contact/page.tsx"
if grep -q "AbortSignal.timeout" "$CT"; then
  echo "  • already has timeout (skip)"
else
  perl -0pi -e "s{const res = await fetch\(\`\\\$\{API\}/content/contact\`, \{ next: \{ revalidate: 60 \} \}\)}{const res = await fetch(\`\\\${API}/content/contact\`, { next: { revalidate: 60 }, signal: AbortSignal.timeout(8000) })}" "$CT"
  grep -q "AbortSignal.timeout" "$CT" && echo "  ✓ contact fetch now times out after 8s" || { echo "  ✗ contact anchor not matched"; exit 1; }
fi

echo
echo "→ Verify:"
grep -n "NEXT_PUBLIC_API_URL:" "$CI"
grep -n "AbortSignal.timeout" "$AB" "$CT"

echo
echo "Done. Now the build can't hang on a slow/dead API — those pages fall back"
echo "to their 'content updating' state instead. Next:"
echo "  cd nexum-web && rm -rf .next && npx tsc --noEmit && npm run build && cd .."
echo "  # the build should now COMPLETE even if the API is asleep"
echo "  git add -A && git commit -m 'fix(build): timeout about/contact fetches + restore real API URL in CI' && git push"
