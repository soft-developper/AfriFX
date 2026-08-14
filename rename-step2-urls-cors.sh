#!/usr/bin/env bash
# ============================================================
# rename-step2-urls-cors.sh  —  AfriFX → Nexum, STEP 2: domain / CORS / links
#
# Domain is now LIVE: web served from https://nexumpay.xyz (Vercel), old
# afrifx.xyz redirects to it. This makes CORS the critical fix: API calls now
# come from nexumpay.xyz and must be allowed.
#
# WHAT IT DOES:
#   1. CORS allowlist (api): ADD https://nexumpay.xyz + www. (KEEP old afrifx
#      entries — old domain still resolves; no reason to break it).
#   2. Web metadata/OG url + wagmi appIcon: afrifx.xyz → nexumpay.xyz.
#   3. Email LINK fallbacks (APP_URL ?? default) and visible link TEXT
#      >afrifx.xyz< → nexumpay.xyz. (These are LINKS/label, not the sender.)
#   4. Support-email display defaults support@afrifx.xyz → support@nexumpay.xyz.
#
# EXPLICITLY NOT TOUCHED:
#   • Email SENDER identity FROM_EMAIL / EMAIL_FROM — Resend domain nexumpay.xyz
#     is NOT yet verified. Sending from an unverified domain gets REJECTED.
#     Leave on afrifx.xyz; flip via EMAIL_FROM env after Resend verification.
#   • Render API host afrifx-api.onrender.com — backend infra, user-invisible,
#     separate migration. Not in code anyway.
#   • Storage keys, env keys, memo tag — earlier/later steps.
#
# ⚠ DASHBOARD ITEMS YOU MUST SET (outside this script):
#   • Render: FRONTEND_URL = https://nexumpay.xyz   (feeds CORS)
#   • Render: APP_URL      = https://nexumpay.xyz   (feeds email links)
#   • Vercel: NEXT_PUBLIC_API_URL = your Render API URL (confirm it's set)
#
# Idempotent. Run from repo root:  cd ~/AfriFX && bash rename-step2-urls-cors.sh
# ============================================================
set -euo pipefail
ROOT="$(pwd)"
[ -d "$ROOT/afrifx-api" ] && [ -d "$ROOT/afrifx-web" ] || { echo "ERROR: run from AfriFX repo root"; exit 1; }

API="$ROOT/afrifx-api"; WEB="$ROOT/afrifx-web"
NEW="nexumpay.xyz"

echo "→ 1/4  CORS: add https://$NEW (keeping old afrifx entries)…"
CORS="$API/src/middleware/cors.ts"
if grep -q "$NEW" "$CORS"; then
  echo "  • CORS already includes $NEW (skip)"
else
  perl -0pi -e "s{('https://afrifx\.xyz',\n\s*'https://www\.afrifx\.xyz',\n)}{\$1    'https://nexumpay.xyz',\n    'https://www.nexumpay.xyz',\n}s" "$CORS"
  grep -q "$NEW" "$CORS" && echo "  ✓ CORS allowlist now includes $NEW + www" || { echo "  ✗ CORS anchor not matched"; exit 1; }
fi

echo "→ 2/4  Web metadata / OG url / wagmi appIcon → $NEW…"
# layout.tsx metadataBase + og url ; wagmi appIcon. These are web-facing, safe.
perl -0pi -e "s{https://afrifx\.xyz/favicon\.svg}{https://nexumpay.xyz/favicon.svg}g" "$WEB/lib/wagmi.ts"
perl -0pi -e "s{new URL\('https://afrifx\.xyz'\)}{new URL('https://nexumpay.xyz')}g" "$WEB/app/layout.tsx"
perl -0pi -e "s{url:(\s*)'https://afrifx\.xyz'}{url:\$1'https://nexumpay.xyz'}g" "$WEB/app/layout.tsx"
echo "  ✓ web metadata + wagmi appIcon updated"

echo "→ 3/4  Email LINK fallbacks + visible link text → $NEW (sender NOT touched)…"
# APP_URL / APP_URL_2 / APP3 fallbacks
find "$API/src" -name "*.ts" -print0 | xargs -0 perl -0pi -e "s{(process\.env\.APP_URL \?\? ')https://afrifx\.xyz(')}{\${1}https://nexumpay.xyz\${2}}g"
# visible link text  >afrifx.xyz<  and the one hardcoded href in notifications.ts
find "$API/src" -name "*.ts" -print0 | xargs -0 perl -0pi -e "s{>afrifx\.xyz<}{>nexumpay.xyz<}g"
perl -0pi -e "s{href=\"https://afrifx\.xyz\"}{href=\"https://nexumpay.xyz\"}g" "$API/src/routes/notifications.ts"
echo "  ✓ email link hrefs + label text updated"

echo "→ 4/4  Support-email display defaults → support@$NEW…"
perl -0pi -e "s{support\@afrifx\.xyz}{support\@nexumpay.xyz}g" "$API/src/routes/content.ts"
perl -0pi -e "s{support\@afrifx\.xyz}{support\@nexumpay.xyz}g" "$WEB/app/admin/content/page.tsx"
echo "  ✓ support-email defaults updated"

echo
echo "→ SANITY — email SENDER must still be afrifx.xyz (unverified nexumpay in Resend):"
grep -n "FROM_EMAIL" "$API/src/services/email/client.ts"

echo
echo "→ SANITY — CORS now covers both domains:"
grep -nE "afrifx\.xyz'|nexumpay\.xyz'" "$CORS"

echo
echo "Done (Step 2). BEFORE it works in prod, set on the dashboards:"
echo "  • Render:  FRONTEND_URL = https://nexumpay.xyz   (CORS)"
echo "  • Render:  APP_URL      = https://nexumpay.xyz   (email links)"
echo "  • Vercel:  NEXT_PUBLIC_API_URL = <your Render API URL>  (confirm set)"
echo
echo "Then:"
echo "  cd afrifx-api && npx tsc --noEmit && npm run build && cd .."
echo "  cd afrifx-web && rm -rf .next && npx tsc --noEmit && npm run build && cd .."
echo "  git add -A && git commit -m 'rebrand(step2): nexumpay.xyz CORS + web URLs + email links (sender unchanged)' && git push"
echo
echo "AFTER you verify nexumpay.xyz in Resend: set Render EMAIL_FROM ="
echo "  'Nexum <notifications@nexumpay.xyz>'  — no code change needed."
